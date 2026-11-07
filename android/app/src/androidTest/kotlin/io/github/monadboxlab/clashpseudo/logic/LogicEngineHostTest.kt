package io.github.monadboxlab.clashpseudo.logic

import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.FlutterException
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import io.github.monadboxlab.clashpseudo.app.PseudoApplication
import io.github.monadboxlab.clashpseudo.app.ApplicationContract as Contract
import io.github.monadboxlab.clashpseudo.bridge.AppBridge
import io.github.monadboxlab.clashpseudo.bridge.BridgeTestState
import io.github.monadboxlab.clashpseudo.message.AppMessage
import io.github.monadboxlab.clashpseudo.nativecore.CoreHost
import io.github.monadboxlab.clashpseudo.vpn.NativeSession
import io.github.monadboxlab.clashpseudo.vpn.PseudoVpnService
import java.io.IOException
import java.nio.ByteBuffer
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Test

class LogicEngineHostTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val application get() = instrumentation.targetContext.applicationContext as PseudoApplication
    private fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)
    private fun field(name: String) = LogicEngineHost::class.java.getDeclaredField(name).apply { isAccessible = true }

    private class Reply : MethodChannel.Result {
        var value: Any? = null
        var error: String? = null
        var replies = 0
        override fun success(result: Any?) { value = result; replies++ }
        override fun error(code: String, message: String?, details: Any?) { error = code; replies++ }
        override fun notImplemented() { error = "missing"; replies++ }
    }

    private class Messenger : BinaryMessenger {
        var call: MethodCall? = null
        var reply: BinaryMessenger.BinaryReply? = null
        override fun send(channel: String, message: ByteBuffer?) = send(channel, message, null)
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            message!!.flip()
            call = StandardMethodCodec.INSTANCE.decodeMethodCall(message)
            reply = callback
        }
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {}
        fun complete(value: Any?) {
            val buffer = StandardMethodCodec.INSTANCE.encodeSuccessEnvelope(value)
            buffer.flip()
            reply!!.reply(buffer)
        }
    }

    private class RestoreMessenger : BinaryMessenger {
        val restoreDispatched = CountDownLatch(1)
        var executeReply: BinaryMessenger.BinaryReply? = null
        var executes = 0
        var afterComplete: () -> Unit = {}
        override fun send(channel: String, message: ByteBuffer?) = send(channel, message, null)
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            message!!.flip()
            val call = StandardMethodCodec.INSTANCE.decodeMethodCall(message)
            if (call.method == "execute") {
                executeReply = callback
                executes++
                if ((call.arguments as Map<*, *>)["action"] == "systemStart") restoreDispatched.countDown()
            } else {
                respond(callback, if (call.method == "runtimeState") mapOf("retain" to true) else null)
            }
        }
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {}
        private fun respond(callback: BinaryMessenger.BinaryReply?, value: Any?) {
            val buffer = StandardMethodCodec.INSTANCE.encodeSuccessEnvelope(value)
            buffer.flip()
            callback?.reply(buffer)
        }
        fun complete(value: Any?) {
            val callback = executeReply
            executeReply = null
            respond(callback, value)
            afterComplete()
        }
    }

    @Test fun coldProcessExecutesRealDartAndReturnsWithoutPreparingCore() {
        // Run this method alone in a fresh instrumentation process. A warm loader
        // fails the cold-start precondition.
        val owner = UUID.randomUUID().toString()
        val operationId = BridgeTestState.field("operationId")
        val completed = CountDownLatch(1)
        val replies = AtomicInteger()
        val outcome = AtomicReference<Map<*, *>?>()
        lateinit var host: LogicEngineHost
        var admitted = false
        var sessionGeneration = -1L
        var beforeCore: CoreHost.Snapshot? = null
        try {
            main {
                assertNull(AppBridge.operationId)
                assertNull(AppBridge.command)
                assertFalse(AppBridge.pendingSystemRestore)
                val session = PseudoVpnService.session.snapshot()
                assertEquals(NativeSession.Phase.STOPPED, session.phase)
                sessionGeneration = session.generation
                beforeCore = PseudoVpnService.core.snapshot()
                assertEquals(CoreHost.Phase.EMPTY, beforeCore!!.phase)
                val coreStatus = io.github.monadboxlab.clashpseudo.nativecore.CoreClient.get(instrumentation.targetContext).status()
                assertEquals(Contract.CORE_PHASE_DISCONNECTED, coreStatus[Contract.CORE_FIELD_PHASE])
                assertNull(coreStatus[Contract.CORE_FIELD_PROCESS_ID])
                host = AppBridge.logic
                assertFalse(host.busy)
                assertFalse("Cold test requires no prior Flutter initialization",
                    FlutterInjector.instance().flutterLoader().initialized())
                // Hold the process writer gate while exercising the real host, loader,
                // engine and channel.
                operationId.set(AppBridge, owner)
                admitted = true
                // The resource handler receives an unavailable core identity and
                // returns its semantic result.
                host.execute(owner, mapOf("action" to "updateResource")) { actual ->
                    outcome.set(actual)
                    replies.incrementAndGet()
                    completed.countDown()
                }
            }
            assertTrue("Actual Dart execution did not return", completed.await(30, TimeUnit.SECONDS))
            val actual = checkNotNull(outcome.get())
            // The assertion requires the Dart resourceStatus result from the started
            // engine.
            assertEquals("Expected the actual Dart unavailable-resource reply",
                "unconfirmed", actual["resourceStatus"])
            assertEquals(false, actual["success"])
            main {
                assertTrue(FlutterInjector.instance().flutterLoader().initialized())
                assertFalse("The real execute call has not drained", host.busy)
                assertEquals(beforeCore, PseudoVpnService.core.snapshot())
                val session = PseudoVpnService.session.snapshot()
                assertEquals(NativeSession.Phase.STOPPED, session.phase)
                assertEquals(sessionGeneration, session.generation)
                assertEquals(1, replies.get())
            }
        } finally {
            if (admitted) main {
                if (AppBridge.operationId == owner) {
                    operationId.set(AppBridge, null)
                    // An executing call retains the actual drain gate on timeout.
                    host.cancel(owner)
                    AppBridge.notifyUi()
                }
            }
        }
    }

    @Test fun restoreWaitsForActualWriterDrainAndCancelledPreparationCannotRestart() {
        val manager = androidx.work.WorkManager.getInstance(instrumentation.targetContext)
        val startupDeadline = android.os.SystemClock.elapsedRealtime() + 45_000
        while (true) {
            var idle = false
            var facts = ""
            main {
                val runtime = AppBridge.runtimeState()
                idle = AppBridge.operationId == null && !AppBridge.logic.busy &&
                    !AppBridge.pendingSystemRestore && runtime["writerBusy"] == false &&
                    runtime["storageReady"] == true && runtime["storageRestoring"] != true
                val runtimeFacts = listOf("phase", "storageReady", "storageRestoring", "storageEpoch",
                    "writerBusy", "scheduleBusy", "resourceBusy", "pendingRestore", "pendingSystemStart")
                    .associateWith { runtime[it] }
                facts = "operationId=${AppBridge.operationId}, action=${AppBridge.command?.get("action")}, " +
                    "logicBusy=${AppBridge.logic.busy}, runtime=$runtimeFacts"
            }
            val work = try {
                manager.getWorkInfosForUniqueWork("update-reconcile").get(5, TimeUnit.SECONDS)
            } catch (error: Exception) {
                throw IllegalStateException("Startup WorkInfo query failed: $facts", error)
            }
            if (work.isNotEmpty() && work.all { it.state.isFinished } && idle) break
            check(android.os.SystemClock.elapsedRealtime() < startupDeadline) {
                "Startup reconciliation did not drain: $facts; work=" +
                    work.map { "${it.id}:${it.state}:attempt=${it.runAttemptCount}" }
            }
            android.os.SystemClock.sleep(20)
        }
        lateinit var host: LogicEngineHost
        var engine: FlutterEngine? = null
        lateinit var savedState: Map<String, Any?>
        lateinit var savedObservationOwners: Set<String>
        var stateSaved = false
        var restoreRequested = false
        var restored = false
        val messenger = RestoreMessenger()
        val id = BridgeTestState.field("operationId")
        val prepared = CountDownLatch(1)
        fun restoreHost() {
            if (!restoreRequested || restored || !stateSaved || host.busy) return
            restored = true
            field("engine").set(host, null)
            try {
                engine?.destroy()
            } finally {
                savedState.forEach { (name, value) -> field(name).set(host, value) }
                @Suppress("UNCHECKED_CAST")
                val owners = field("observationOwners").get(host) as MutableSet<String>
                owners.clear()
                owners.addAll(savedObservationOwners)
            }
        }
        messenger.afterComplete = ::restoreHost
        try {
            main {
                assertNull(AppBridge.operationId)
                assertFalse(AppBridge.pendingSystemRestore)
                assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
                host = AppBridge.logic
                savedState = listOf("engine", "channel", "ready", "syncing", "stateDirty")
                    .associateWith { field(it).get(host) }
                @Suppress("UNCHECKED_CAST")
                val owners = field("observationOwners").get(host) as MutableSet<String>
                savedObservationOwners = owners.toSet()
                stateSaved = true
                engine = FlutterEngine(application, null, false)
                field("engine").set(host, engine)
                field("ready").set(host, true)
                owners.add("restore-fixture")
                field("channel").set(host, MethodChannel(messenger, "restore-test"))
                id.set(AppBridge, "test-previous-writer")
                host.execute("test-previous-writer", mapOf("action" to "test")) {}
                AppBridge.restoreSystemStart { assertNull(it); prepared.countDown() }
                // The writer remains busy until the actual Dart execution returns.
                id.set(AppBridge, null)
                assertTrue(host.busy)
                assertTrue(AppBridge.pendingSystemRestore)
            }
            Thread.sleep(180)
            main {
                assertEquals(1, messenger.executes)
                assertTrue(AppBridge.pendingSystemRestore)
                messenger.complete(mapOf("success" to true))
            }
            assertTrue(messenger.restoreDispatched.await(2, TimeUnit.SECONDS))
            main {
                assertEquals(2, messenger.executes)
                assertTrue(host.busy)
                assertTrue(AppBridge.cancelSystemRestore())
                assertNull(AppBridge.operationId)
                assertEquals(true, AppBridge.runtimeState()["writerBusy"])
                assertTrue(host.busy)
                // The cancelled owner's late start descriptor is discarded.
                messenger.complete(mapOf("success" to true, "systemStart" to mapOf(
                    "id" to "one", "revision" to 1, "mode" to "rule")))
            }
            assertTrue(prepared.await(2, TimeUnit.SECONDS))
            main {
                assertFalse(host.busy)
                assertNull(AppBridge.operationId)
                assertFalse(AppBridge.pendingSystemRestore)
                assertEquals(false, AppBridge.runtimeState()["writerBusy"])
            }
        } finally {
            main {
                AppBridge.cancelSystemRestore()
                id.set(AppBridge, null)
                restoreRequested = true
                // If the operation is still running, wait for reply processing before restoring LogicEngineHost fields.
                restoreHost()
            }
        }
    }

    @Test fun realHeadlessSnapshotAllowsUnownedReadButRejectsOldRuntimeAndOwner() {
        val manager = androidx.work.WorkManager.getInstance(instrumentation.targetContext)
        val deadline = android.os.SystemClock.elapsedRealtime() + 45_000
        while (true) {
            var idle = false
            main { idle = AppBridge.runtimeState()["writerBusy"] == false }
            val work = manager.getWorkInfosForUniqueWork("update-reconcile").get(5, TimeUnit.SECONDS)
            if (work.isNotEmpty() && work.all { it.state.isFinished } && idle) break
            check(android.os.SystemClock.elapsedRealtime() < deadline) { "Startup task has not exited" }
            android.os.SystemClock.sleep(20)
        }
        lateinit var host: LogicEngineHost
        var retained = false
        fun platformHandler(engine: FlutterEngine): BinaryMessenger.BinaryMessageHandler {
            // Use the production handler registered in the actual engine and StandardMethodCodec.
            val executor = engine.dartExecutor
            val messenger = executor.javaClass.getDeclaredField("dartMessenger").apply { isAccessible = true }.get(executor)
            val handlers = messenger.javaClass.getDeclaredField("messageHandlers").apply { isAccessible = true }
                .get(messenger) as Map<*, *>
            val entry = checkNotNull(handlers[AppBridge.CHANNEL])
            return entry.javaClass.getDeclaredField("handler").apply { isAccessible = true }.get(entry)
                as BinaryMessenger.BinaryMessageHandler
        }
        fun invoke(handler: BinaryMessenger.BinaryMessageHandler, method: String, arguments: Map<String, Any?>): Any? {
            val message = StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall(method, arguments)).apply { flip() }
            var envelope: ByteBuffer? = null
            var replies = 0
            handler.onMessage(message) { envelope = it; replies++ }
            assertEquals(1, replies)
            return StandardMethodCodec.INSTANCE.decodeEnvelope(checkNotNull(envelope).apply { flip() })
        }
        fun rejected(handler: BinaryMessenger.BinaryMessageHandler, method: String, arguments: Map<String, Any?>) {
            try {
                invoke(handler, method, arguments)
                fail("$method did not reject an expired request or a request without an owner")
            } catch (error: FlutterException) {
                assertEquals("expired", error.code)
                assertNotNull(AppMessage.fromMap(error.details))
            }
        }
        try {
            val completed = CompletableFuture<Any?>()
            main {
                assertNull(AppBridge.operationId)
                assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
                assertEquals(CoreHost.Phase.EMPTY, PseudoVpnService.core.snapshot().phase)
                host = AppBridge.logic
                host.retainPlatform(true)
                retained = true
                // The actual Dart CoreRuntime._stop first reads platform state through a snapshot without an owner.
                host.read("stop", emptyMap(), object : MethodChannel.Result {
                    override fun success(result: Any?) { completed.complete(result) }
                    override fun error(code: String, message: String?, details: Any?) {
                        completed.completeExceptionally(AssertionError("$code/$message/$details"))
                    }
                    override fun notImplemented() { completed.completeExceptionally(AssertionError("stop is not implemented")) }
                })
            }
            assertNull(completed.get(30, TimeUnit.SECONDS))
            main {
                val engine = field("engine").get(host) as FlutterEngine
                assertTrue(engine.dartExecutor.isExecutingDart)
                val runtime = field("serial").getLong(host)
                val current = platformHandler(engine)
                val snapshot = invoke(current, "snapshot", emptyMap()) as Map<*, *>
                val expected = AppBridge.runtimeState()
                for (key in listOf("phase", "generation", "storageReady", "storageEpoch", "core")) {
                    assertEquals(key, expected[key], snapshot[key])
                }
                rejected(current, "snapshot", mapOf("owner" to "old-${UUID.randomUUID()}"))
                rejected(current, "paths", emptyMap())
                rejected(current, "publishStore", emptyMap())
                val oldRuntime = try {
                    AppBridge.attachWork(engine, runtime - 1)
                    platformHandler(engine)
                } finally {
                    AppBridge.attachWork(engine, runtime)
                }
                rejected(oldRuntime, "snapshot", emptyMap())
                rejected(oldRuntime, "snapshot", mapOf("owner" to "old-owner"))
                rejected(oldRuntime, Contract.CORE_CHANNEL_LOCAL_INTERFACES, emptyMap())
                assertTrue(host.current(runtime))
                assertFalse(host.busy)
                assertNull(AppBridge.operationId)
                assertEquals(CoreHost.Phase.EMPTY, PseudoVpnService.core.snapshot().phase)
            }
        } finally {
            if (retained) main { host.retainPlatform(false) }
        }
    }

    @Test fun stoppedTrafficReturnsEmptyWithoutStartingAnEngine() = main {
        assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
        val host = LogicEngineHost(application)
        val traffic = Reply()
        host.traffic(traffic)
        assertEquals(1, traffic.replies)
        assertNull(traffic.error)
        val value = traffic.value as Map<*, *>
        assertEquals(false, value["fresh"])
        assertEquals("STOPPED", value["phase"])
        assertEquals(emptyList<Any>(), value["points"])
        assertFalse(value.containsKey("connections"))
        assertNull(field("engine").get(host))
        val connections = Reply()
        host.connections(null, null, connections)
        val connectionValue = connections.value as Map<*, *>
        assertTrue(connectionValue.containsKey("connections"))
        assertFalse(connectionValue.containsKey("phase"))
        assertFalse(connectionValue.containsKey("failed"))
        assertNull(field("engine").get(host))
    }

    @Test fun trafficKeepsEngineUntilReplyAndSharesQueryGate() = main {
        assertEquals(NativeSession.Phase.STOPPED, PseudoVpnService.session.snapshot().phase)
        val host = LogicEngineHost(application)
        val engine = FlutterEngine(application, null, false)
        val messenger = Messenger()
        field("engine").set(host, engine)
        field("ready").set(host, true)
        field("channel").set(host, MethodChannel(messenger, "traffic-test"))
        try {
            val traffic = Reply()
            host.traffic(traffic)
            assertEquals("traffic", messenger.call!!.method)
            val args = messenger.call!!.arguments as Map<*, *>
            assertTrue(args.containsKey("state"))
            assertFalse(args.containsKey("detail"))
            assertSame(engine, field("engine").get(host))
            assertEquals(true, field("querying").get(host))
            val other = Reply()
            host.connections(null, null, other)
            assertEquals("waiting", other.error)
            messenger.complete(mapOf("points" to emptyList<Any>(), "fresh" to false))
            assertEquals(1, traffic.replies)
            assertNull(traffic.error)
            assertFalse((traffic.value as Map<*, *>).containsKey("connections"))
            assertEquals(false, field("querying").get(host))
            assertNull(field("engine").get(host))
        } finally {
            if (field("engine").get(host) != null) {
                engine.destroy()
                field("engine").set(host, null)
            }
        }
    }
}

class LogicEngineHostErrorTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val original = "https://user:pass@fixture.test/?token=原文🙂\nAuthorization: Bearer fixture"
    private fun field(name: String) = LogicEngineHost::class.java.getDeclaredField(name).apply { isAccessible = true }
    private fun decoded(value: Any?): Any? {
        val buffer = StandardMethodCodec.INSTANCE.encodeSuccessEnvelope(value)
        buffer.flip()
        return StandardMethodCodec.INSTANCE.decodeEnvelope(buffer)
    }

    private class Reply : MethodChannel.Result {
        var value: Any? = null
        var error: AppMessage? = null
        var replies = 0
        override fun success(result: Any?) { value = result; replies++ }
        override fun error(code: String, message: String?, details: Any?) {
            error = AppMessage.fromMap(details)
            replies++
        }
        override fun notImplemented() { fail("Unexpected missing method") }
    }

    private class Messenger : BinaryMessenger {
        var call: MethodCall? = null
        var callback: BinaryMessenger.BinaryReply? = null
        var failure: Throwable? = null
        override fun send(channel: String, message: ByteBuffer?) = send(channel, message, null)
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            message!!.flip()
            val call = StandardMethodCodec.INSTANCE.decodeMethodCall(message)
            this.call = call
            failure?.let { throw it }
            if (call.method == "runtimeState") {
                success(callback, mapOf("retain" to true))
            } else {
                this.callback = callback
            }
        }
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {}
        fun success(value: Any?) = success(callback, value)
        fun success(callback: BinaryMessenger.BinaryReply?, value: Any?) {
            val buffer = StandardMethodCodec.INSTANCE.encodeSuccessEnvelope(value)
            buffer.flip()
            callback!!.reply(buffer)
        }
        fun error(code: String, message: String?, details: Any?) {
            val buffer = StandardMethodCodec.INSTANCE.encodeErrorEnvelope(code, message, details)
            buffer.flip()
            callback!!.reply(buffer)
        }
    }

    private fun withHost(action: (LogicEngineHost, Messenger) -> Unit) = instrumentation.runOnMainSync {
        val application = instrumentation.targetContext.applicationContext as PseudoApplication
        val host = LogicEngineHost(application)
        val engine = FlutterEngine(application, null, false)
        val messenger = Messenger()
        field("engine").set(host, engine)
        field("ready").set(host, true)
        @Suppress("UNCHECKED_CAST")
        (field("observationOwners").get(host) as MutableSet<String>).add("fixture-retention")
        field("channel").set(host, MethodChannel(messenger, "logic-errors"))
        try {
            action(host, messenger)
        } finally {
            field("engine").set(host, null)
            engine.destroy()
        }
    }

    @Test fun executionChannelErrorsKeepTypedAndUnstructuredDiagnostics() = withHost { host, messenger ->
        val typed = AppMessage("futureMessage", mapOf("futureArgument" to original), original)
        val unknown = mapOf("future" to mapOf("Authorization" to original), "values" to listOf(false, null, 1))
        for (details in listOf(typed.toMap(), unknown, null)) {
            var replies = 0
            var outcome: Map<*, *>? = null
            host.execute("owner", mapOf("action" to "fixture")) { outcome = it; replies++ }
            messenger.error("actual-code", original, details)
            assertEquals(1, replies)
            val actual = AppMessage.fromMap(outcome!!["message"])!!
            if (details == typed.toMap()) {
                assertEquals(typed, actual)
            } else {
                assertEquals(details, decoded(details))
                assertEquals("actual-code: $original\n${decoded(details)}", actual.detail)
            }
            assertFalse(host.busy)
            assertEquals(false, field("executing").get(host))
        }
    }

    @Test fun observationsKeepTypedAndUnstructuredDiagnostics() = withHost { host, messenger ->
        val typed = AppMessage("futureMessage", mapOf("futureArgument" to original), original)
        val unknown = mapOf("future" to listOf(original, false, null))
        for (method in listOf("connections", "clearInactiveConnections", "traffic")) {
            for (details in listOf(typed.toMap(), unknown)) {
                val reply = Reply()
                when (method) {
                    "connections" -> host.connections(null, null, reply)
                    "clearInactiveConnections" -> host.clearInactiveConnections(null, null, reply)
                    else -> host.traffic(reply)
                }
                assertEquals(method, messenger.call!!.method)
                messenger.error("actual-code", original, details)
                assertEquals(1, reply.replies)
                assertNull(reply.value)
                if (details == typed.toMap()) assertEquals(typed, reply.error)
                else {
                    assertEquals(details, decoded(details))
                    assertEquals("actual-code: $original\n${decoded(details)}", reply.error!!.detail)
                }
                assertEquals(false, field("querying").get(host))
            }
        }
    }

    @Test fun synchronousMessengerFailuresFinishExecutionOnceAndAllowRetry() = withHost { host, messenger ->
        for (failure in listOf(IOException(original), UnsatisfiedLinkError(original))) {
            messenger.failure = failure
            var replies = 0
            var outcome: Map<*, *>? = null
            host.execute("owner", mapOf("action" to "fixture")) { outcome = it; replies++ }
            assertEquals(1, replies)
            assertEquals(failure.stackTraceToString(), AppMessage.fromMap(outcome!!["message"])!!.detail)
            assertFalse(host.busy)
            assertEquals(false, field("executing").get(host))
            messenger.failure = null
            val actual = mapOf("success" to true, "future" to listOf(original, false, null))
            host.execute("retry", mapOf("action" to "fixture")) { outcome = it; replies++ }
            assertTrue(host.busy)
            messenger.success(actual)
            assertEquals(2, replies)
            assertEquals(actual, outcome)
            assertFalse(host.busy)
        }
    }

    @Test fun synchronousObservationFailuresReplyOnceAndReleaseTheQuerySlot() = withHost { host, messenger ->
        for (failure in listOf(IOException(original), UnsatisfiedLinkError(original))) {
            messenger.failure = failure
            val reply = Reply()
            host.traffic(reply)
            assertEquals(1, reply.replies)
            assertEquals(failure.stackTraceToString(), reply.error!!.detail)
            assertEquals(false, field("querying").get(host))
            messenger.failure = null
            val retry = Reply()
            host.connections(null, null, retry)
            val actual = mapOf("future" to original)
            messenger.success(actual)
            assertEquals(1, retry.replies)
            assertNull(retry.error)
            assertEquals(actual, retry.value)
            assertEquals(false, field("querying").get(host))
        }
    }

    @Test fun invalidExecutionResultsKeepTheirOriginalValue() = withHost { host, messenger ->
        val invalid = listOf(original, false, null)
        var outcome: Map<*, *>? = null
        host.execute("owner", mapOf("action" to "fixture")) { outcome = it }
        messenger.success(invalid)
        assertEquals(invalid.toString(), AppMessage.fromMap(outcome!!["message"])!!.detail)
        assertFalse(host.busy)
    }

    @Test fun duplicateOldCompletionCannotDrainOrReplaceTheNextExecution() = withHost { host, messenger ->
        var oldReplies = 0
        var newReplies = 0
        host.execute("old", mapOf("action" to "fixture")) { oldReplies++ }
        val oldCallback = messenger.callback
        messenger.success(mapOf("success" to true))
        host.execute("new", mapOf("action" to "fixture")) { newReplies++ }
        messenger.success(oldCallback, mapOf("success" to false, "future" to original))
        assertEquals(1, oldReplies)
        assertEquals(0, newReplies)
        assertTrue(host.ownsOperation("new"))
        messenger.success(mapOf("success" to true))
        assertEquals(1, newReplies)
        assertFalse(host.busy)
    }

    @Test fun namedObservationReleasesCannotClearAnotherOwnerOrReacquireFromAnOldStateReply() = withHost { host, messenger ->
        val runtime = field("serial").getLong(host)
        host.retain(runtime, true, "old")
        host.retain(runtime, true, "replacement")
        host.retain(runtime, false, "old")
        host.retain(runtime - 1, false, "replacement")
        assertEquals(setOf("fixture-retention", "replacement"), field("observationOwners").get(host))
        host.reconcile() // Messenger returns the legacy unowned retain=true.
        assertEquals("runtimeState", messenger.call!!.method)
        assertEquals(setOf("fixture-retention", "replacement"), field("observationOwners").get(host))
        host.retain(runtime, false, "replacement")
        host.retain(runtime, false, "old")
        assertEquals(setOf("fixture-retention"), field("observationOwners").get(host))
    }

    @Test fun detailQueriesRequireAndForwardTheirExactLeaseWithoutMakingListReadsOwners() = withHost { host, messenger ->
        val detail = mapOf("id" to "connection", "generation" to 7)
        for (clear in listOf(false, true)) {
            val missing = Reply()
            if (clear) host.clearInactiveConnections(detail, null, missing) else host.connections(detail, null, missing)
            assertEquals(1, missing.replies)
            assertNotNull(missing.error)
            assertEquals(false, field("querying").get(host))
            val reply = Reply()
            if (clear) host.clearInactiveConnections(detail, "pin", reply) else host.connections(detail, "pin", reply)
            val args = messenger.call!!.arguments as Map<*, *>
            assertEquals(detail, args["detail"])
            assertEquals("pin", args["detailOwner"])
            assertEquals(0, reply.replies)
            messenger.success(mapOf("connections" to emptyList<Any>()))
            assertEquals(1, reply.replies)
        }
        val list = Reply()
        host.connections(null, null, list)
        assertNull((messenger.call!!.arguments as Map<*, *>)["detailOwner"])
        messenger.success(mapOf("connections" to emptyList<Any>()))
        assertEquals(1, list.replies)
    }

    @Test fun detailReleaseWaitsForItsActualReplyAndKeepsTheOriginalError() = withHost { host, messenger ->
        val reply = Reply()
        val error = AppMessage("futureMessage", detail = "cause $original\nSuppressed: close")
        host.releaseDetail("old-pin", reply)
        assertEquals("releaseDetail", messenger.call!!.method)
        assertEquals(mapOf("detailOwner" to "old-pin"), messenger.call!!.arguments)
        assertEquals(0, reply.replies)
        assertEquals(1, field("releasingDetails").getInt(host))
        messenger.error("actual", null, error.toMap())
        assertEquals(1, reply.replies)
        assertEquals(error, reply.error)
        assertEquals(0, field("releasingDetails").getInt(host))
        messenger.success(null) // Duplicate callbacks cannot decrement drain twice.
        assertEquals(1, reply.replies)
        assertEquals(0, field("releasingDetails").getInt(host))
    }

    @Test fun rejectedDetailReleasePreservesItsCauseAndDoesNotLeaveADrain() = withHost { host, messenger ->
        for (failure in listOf(IOException(original), UnsatisfiedLinkError(original))) {
            messenger.failure = failure
            val reply = Reply()
            host.releaseDetail("pin", reply)
            assertEquals(1, reply.replies)
            assertEquals(failure.stackTraceToString(), reply.error!!.detail)
            assertEquals(0, field("releasingDetails").getInt(host))
        }
    }

    @Test fun synchronousStateFailuresDoNotKeepTheSyncGateClosed() = withHost { host, messenger ->
        for (failure in listOf(IOException(original), UnsatisfiedLinkError(original))) {
            messenger.failure = failure
            host.reconcile()
            assertEquals(false, field("syncing").get(host))
            messenger.failure = null
            host.reconcile()
            assertEquals("runtimeState", messenger.call!!.method)
            assertEquals(false, field("syncing").get(host))
            assertEquals(setOf("fixture-retention"), field("observationOwners").get(host))
        }
    }
}
