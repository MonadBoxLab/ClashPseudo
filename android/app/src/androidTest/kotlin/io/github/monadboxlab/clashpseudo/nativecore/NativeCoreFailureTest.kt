package io.github.monadboxlab.clashpseudo.nativecore

import android.util.Base64
import android.util.Log
import io.github.monadboxlab.clashpseudo.debug.CoreFixtureContract as Fixture
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.Rule
import org.junit.rules.ErrorCollector
import java.util.concurrent.Callable
import java.io.Closeable
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

class NativeCoreFailureTest {
    @get:Rule val failures = ErrorCollector()

    @Test fun androidTrustPemInitializesNativeWithoutPreparingCore() {
        runScene(Fixture.TRUST) { result ->
            assertSuccess(result.getJSONObject("trust"))
            assertTrue(result.getJSONObject("trust").getJSONObject("value").getBoolean("initialized"))
            assertStopped(result.getJSONObject("before").getJSONObject("value"))
        }
    }

    @Test fun invalidParametersKeepDescriptorInKotlinAndRecover() {
        repeat(3) { round ->
            runScene(Fixture.BAD_REVISION) { result ->
                assertSuccess(result.getJSONObject("prepare"))
                val error = nativeError(result.getJSONObject("attach"))
                assertTrue(error, error.contains("specification revision"))
                assertEquals(result.getLong("originalInode"), result.getLong("retainedInode"))
                assertTrue(result.getInt("retainedFd") > 0)
                assertTrue("The independent copy acquired by Go must be closed", result.getBoolean("transferredConsumed"))
                assertFalse(result.getJSONObject("attachedState").getJSONObject("value").getBoolean("attached"))
                assertDescriptorReleased(result)
            }
            assertRecovery(round, "preflight-revision")
        }
    }

    @Test fun stackConstructionFailureConsumesDescriptorAndRecovers() {
        repeat(3) { round ->
            runScene(Fixture.BAD_STACK, cleanupFailed = true) { result ->
                assertSuccess(result.getJSONObject("prepare"))
                val error = nativeError(result.getJSONObject("attach"))
                assertTrue(error, error.contains("invalid TCP congestion control"))
                assertTrue(result.getBoolean("transferredConsumed"))
                assertEquals(result.getLong("originalInode"), result.getLong("retainedInode"))
                assertFalse(result.getJSONObject("attachedState").getJSONObject("value").getBoolean("attached"))
                assertDescriptorReleased(result)
            }
            assertRecovery(round, "stack")
        }
    }

    @Test fun androidUnsupportedKernelStacksPrepareWithoutRejecting() {
        for (scene in listOf(Fixture.SYSTEM_INTERFACE, Fixture.MIXED_INTERFACE)) {
            runScene(scene) { result ->
                assertSuccess(result.getJSONObject("prepare"))
            }
        }
    }

    @Test fun refusedProtectPreventsConnectionAndRecovers() = checkProtectFailure(Fixture.REFUSE_PROTECT)
    @Test fun throwingProtectIsContainedAndRecovers() = checkProtectFailure(Fixture.THROW_PROTECT)

    @Test fun connectionJniRejectsUnavailableCoreAndSummaryHasNoFullSnapshot() {
        runScene(Fixture.CONNECTIONS) { result ->
            for (name in listOf("unavailable", "oversized", "close", "previewConnections")) {
                assertTrue("$name must preserve the actual call error", nativeError(result.getJSONObject(name)).isNotEmpty())
                assertTrue(result.getJSONObject(name).getJSONObject("receipt").getBoolean("exited"))
            }
            assertSuccess(result.getJSONObject("prepare"))
            val summary = result.getJSONObject("summary").getJSONObject("value")
            assertFalse(summary.has("traffic"))
            assertFalse(summary.has("connections"))
            assertTrue(summary.has("uploadTotal"))
            assertTrue(summary.has("downloadTotal"))
        }
    }

    @Test fun modeRoundTripRejectsInvalidInputAndClearsOnStop() {
        runScene(Fixture.MODES) { result ->
            assertEquals("rule", result.getJSONObject("initial").getJSONObject("value").getString("mode"))
            val changes = result.getJSONArray("changes")
            assertEquals(3, changes.length())
            for ((index, mode) in listOf("global", "direct", "rule").withIndex()) {
                val change = changes.getJSONObject(index)
                assertSuccess(change.getJSONObject("set"))
                assertEquals(mode, change.getJSONObject("read").getJSONObject("value").getString("mode"))
            }
            assertTrue(nativeError(result.getJSONObject("invalid")).isNotEmpty())
            assertEquals("rule", result.getJSONObject("afterInvalid").getJSONObject("value").getString("mode"))
            assertSuccess(result.getJSONObject("stop"))
            assertEquals("", result.getJSONObject("stoppedMode").getJSONObject("value").getString("mode"))
            assertTrue(nativeError(result.getJSONObject("stoppedSet")).isNotEmpty())
        }
    }

    @Test fun previewUsesRealJniUtf8AndRestoresWithoutTun() {
        runScene(Fixture.UTF8_STRATEGIES) { result ->
            assertSuccess(result.getJSONObject("prepare"))
            val sequence = result.getJSONArray("sequence")
            assertEquals(3, sequence.length())
            for ((index, expected) in listOf("节点🌐", "REJECT", "节点🌐").withIndex()) {
                val item = sequence.getJSONObject(index)
                assertSuccess(item.getJSONObject("select"))
                val stream = item.getJSONObject("groups")
                assertSuccess(stream)
                val records = stream.getJSONArray("records")
                val group = (0 until records.length()).map(records::getJSONObject).single { it.getString("name") == "出口🌐" }
                assertEquals(expected, group.getString("now"))
                assertEquals(records.length().toLong(), stream.getJSONObject("terminal").getLong("recordCount"))
            }
            assertFalse(result.getJSONObject("snapshot").getJSONObject("value").getBoolean("attached"))
        }
    }

    @Test fun descriptorConsumptionChecksOriginalResourceAfterNumberReuse() {
        CoreIpcTestDriver.fixture().use { driver ->
            val reply = driver.fixture(Fixture.FD_REUSE).await()
            assertTrue(reply.terminal.toString(), reply.terminal.getBoolean("complete"))
            val result = reply.value
            assertTrue("Ownership probe must reject the original resource while it is still open", result.getBoolean("liveOriginalOwned"))
            assertTrue("The FD number must actually be reused", result.getBoolean("reusedNumber"))
            assertTrue(result.getBoolean("differentInode"))
            assertFalse(result.getBoolean("oldOwnedAfterReuse"))
            assertFalse(result.getBoolean("oldOwnedAfterClose"))
            driver.exit()
            CoreIpcTestDriver.removeFixtureHome(driver.context, result)
        }
    }

    @Test fun outputDetachFailureClosesOnlyTransferredInputAndKeepsJavaOwners() =
        assertPartialHandoff(Fixture.OUTPUT_HANDOFF_FAILURE, "output", listOf("input", "output"))

    @Test fun tunDetachFailureClosesTransferredInputAndOutputAndKeepsJavaOwner() =
        assertPartialHandoff(Fixture.TUN_HANDOFF_FAILURE, "TUN", listOf("input", "output", "TUN"))

    private fun assertPartialHandoff(scene: Int, failedName: String, order: List<String>) {
        runScene(scene) { result ->
            val receipt = result.getJSONObject("handoffReceipt")
            assertFalse(receipt.toString(), receipt.getBoolean("accepted"))
            assertFalse(receipt.toString(), receipt.getBoolean("ok"))
            assertTrue(receipt.toString(), receipt.getBoolean("exited"))
            val error = receipt.getJSONObject("error")
            assertEquals("callFailed", error.getString("code"))
            val trace = error.getString("message")
            assertEquals(result.getString("expectedException"), trace)
            assertTrue(trace, trace.contains("Caused by: java.io.IOException: $failedName detach cause 原文"))
            assertTrue(trace, trace.contains("Suppressed: java.lang.IllegalStateException: $failedName detach suppressed 原文"))
            assertFalse("Native cleanup must not produce EBADF from a duplicate close", error.has("suppressed"))
            val actualOrder = result.getJSONArray("detachOrder")
            assertEquals(order, (0 until actualOrder.length()).map(actualOrder::getString))
            val before = result.getJSONArray("beforeJavaClose")
            val after = result.getJSONArray("afterJavaClose")
            assertEquals(3, before.length())
            assertEquals(3, after.length())
            val transferredNumbers = mutableSetOf<Int>()
            for (index in 0 until before.length()) {
                val descriptor = before.getJSONObject(index)
                val name = descriptor.getString("name")
                val transferred = name == "input" || (name == "output" && failedName == "TUN")
                assertEquals(name, transferred, descriptor.getBoolean("transferred"))
                assertEquals(name, if (name in order) 1 else 0, descriptor.getInt("detachCalls"))
                assertEquals(name, 0, descriptor.getInt("javaCloseCalls"))
                assertEquals("Java must still own untransferred FDs: $name", !transferred, descriptor.getBoolean("originalOwned"))
                if (transferred) {
                    transferredNumbers += descriptor.getInt("fd")
                    assertEquals(name, android.system.OsConstants.EBADF, descriptor.getInt("closedErrno"))
                }
                val closed = after.getJSONObject(index)
                assertEquals(name, closed.getString("name"))
                assertEquals("Each Java owner must close exactly once: $name", 1, closed.getInt("javaCloseCalls"))
                assertFalse(name, closed.getBoolean("originalOwned"))
            }
            val replacements = result.getJSONArray("replacementsAfterJavaClose")
            assertEquals(if (failedName == "TUN") 2 else 1, replacements.length())
            assertEquals(transferredNumbers, (0 until replacements.length()).map {
                replacements.getJSONObject(it).getInt("fd")
            }.toSet())
            for (index in 0 until replacements.length()) {
                val replacement = replacements.getJSONObject(index)
                assertTrue("The FD number must belong to a different resource", replacement.getBoolean("differentResource"))
                assertTrue("A detached Java wrapper must not close the reused FD", replacement.getBoolean("replacementOwned"))
            }
            assertEquals("reject_handoff produces no frames; the reader must reach actual EOF", 0, result.getInt("outputBytesAfterDrain"))
            assertSuccess(result.getJSONObject("handoffSnapshot"))
            assertStopped(result.getJSONObject("handoffSnapshot").getJSONObject("value"))
            assertTrue(result.getBoolean("unrelatedZeroBefore"))
            assertTrue("reject_handoff must not close FD0 that was not handed off: ${result.getString("unrelatedZeroPath")}",
                result.getBoolean("unrelatedZeroAfterNativeReturn"))
        }
    }

    private fun checkProtectFailure(scene: Int) {
        repeat(3) { round ->
            ProviderServer().use { server ->
                runScene(scene, JSONObject().put("port", server.port).put("token", server.requestId)) { result ->
                    val callbacks = result.getJSONObject("callbacks")
                    assertTrue("JNI did not invoke the socket callback", callbacks.getInt("calls") > 0)
                    assertTrue(callbacks.isNull("invalidSocket"))
                    val state = result.getJSONObject("snapshot").getJSONObject("value")
                    assertEquals(callbacks.getInt("calls").toLong(), state.getLong("refused"))
                    assertEquals(0L, state.getLong("protected"))
                    assertEquals(0, server.accepted.get())
                }
            }
            ProviderServer().use { server ->
                runScene(Fixture.ACCEPT_PROTECT, JSONObject().put("port", server.port).put("token", server.requestId)) { result ->
                    assertSuccess(result.getJSONObject("prepare"))
                    assertTrue("Provider response was not sent", server.served.await(3, TimeUnit.SECONDS))
                    server.assertHealthy()
                    assertTrue(result.getJSONObject("callbacks").getInt("calls") > 0)
                    assertTrue(result.getJSONObject("callbacks").isNull("invalidSocket"))
                    val state = result.getJSONObject("snapshot").getJSONObject("value")
                    assertTrue(state.getLong("protected") > 0)
                    assertEquals(0L, state.getLong("refused"))
                    assertTrue("Explicit provider cache path was not preserved", result.getBoolean("providerExists"))
                    assertArrayEquals(server.body.toByteArray(Charsets.UTF_8), Base64.decode(result.getString("provider"), Base64.DEFAULT))
                    assertEquals(1, result.getInt("matchingFiles"))
                }
            }
            assertEquals("Provider test thread did not exit", 0, Thread.getAllStackTraces().keys.count { it.name == "native-test-provider" && it.isAlive })
            Log.i("NativeCoreFailureTest", "scene=$scene round=$round appPid=${android.os.Process.myPid()}")
        }
    }

    private fun assertDescriptorReleased(result: JSONObject) {
        val retained = result.getJSONArray("matchingDescriptorsAfterAttach")
        assertEquals(result.toString(), 1, retained.length())
        assertEquals(result.getInt("retainedFd"), retained.getInt(0))
        assertEquals(result.toString(), 0, result.getJSONArray("matchingDescriptorsAfterRetainedClose").length())
    }

    private fun assertRecovery(round: Int, scene: String) {
        runScene(Fixture.UTF8_STRATEGIES) { result ->
            assertSuccess(result.getJSONObject("prepare"))
            assertTrue(result.getJSONObject("snapshot").getJSONObject("value").getBoolean("prepared"))
        }
        Log.i("NativeCoreFailureTest", "$scene round=$round recoveryProcessExited=true")
    }

    private fun runScene(scene: Int, args: JSONObject = JSONObject(), cleanupFailed: Boolean = false,
        assertResult: (JSONObject) -> Unit) {
        CoreIpcTestDriver.fixture().use { driver ->
            val reply = driver.fixture(scene, args).await()
            assertTrue(reply.terminal.toString(), reply.terminal.getBoolean("complete"))
            assertTrue(reply.terminal.getBoolean("exited"))
            val result = reply.value
            for (assertion in listOf<() -> Unit>(
                { assertSuccess(result.getJSONObject("shutdown")) },
                { assertStopped(result.getJSONObject("after").getJSONObject("value"), cleanupFailed) },
                { assertResult(result) },
            )) failures.checkSucceeds(Callable {
                try { assertion() }
                catch (error: AssertionError) { throw AssertionError(result.toString(), error) }
            })
            driver.exit()
            assertTrue(driver.deathConfirmed)
            CoreIpcTestDriver.removeFixtureHome(driver.context, result)
        }
    }

    private class ProviderServer : Closeable {
        val requestId = UUID.randomUUID().toString()
        val body = "proxies:\n  - {name: fixture, type: socks5, server: 127.0.0.1, port: 9}\n"
        val accepted = AtomicInteger()
        val served = CountDownLatch(1)
        private val closing = AtomicBoolean()
        private val failure = AtomicReference<Throwable?>()
        private val listener = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        private val client = AtomicReference<Socket?>()
        val port = listener.localPort
        private val worker = Thread({
            try {
                listener.soTimeout = 15000
                listener.accept().use { socket ->
                    client.set(socket); socket.soTimeout = 3000; accepted.incrementAndGet()
                    val input = socket.getInputStream().bufferedReader(Charsets.US_ASCII)
                    check(input.readLine() == "GET /$requestId HTTP/1.1")
                    while (true) { val line = input.readLine() ?: error("Incomplete HTTP headers"); if (line.isEmpty()) break }
                    val bytes = body.toByteArray(Charsets.UTF_8)
                    socket.getOutputStream().apply {
                        write(("HTTP/1.1 200 OK\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n").toByteArray(Charsets.US_ASCII))
                        write(bytes); flush()
                    }
                    served.countDown()
                }
            } catch (error: Throwable) { if (!closing.get()) failure.set(error) }
        }, "native-test-provider").apply { start() }
        fun assertHealthy() { failure.get()?.let { throw AssertionError("Provider server failed", it) } }
        override fun close() {
            closing.set(true)
            try { listener.close(); client.get()?.close() } finally { worker.join(5000) }
            assertFalse("Provider thread did not exit", worker.isAlive)
            assertHealthy()
        }
    }

    companion object {
        fun assertSuccess(call: JSONObject) {
            val terminal = call.getJSONObject("terminal")
            val receipt = call.getJSONObject("receipt")
            assertTrue(terminal.toString(), terminal.getBoolean("complete"))
            assertTrue(terminal.getBoolean("exited"))
            assertTrue(receipt.toString(), receipt.getBoolean("exited"))
            assertTrue(receipt.toString(), receipt.isNull("error"))
            assertTrue(terminal.toString(), terminal.isNull("error"))
        }
        fun nativeError(call: JSONObject): String {
            val receipt = call.getJSONObject("receipt")
            assertTrue("The actual invoke return must be preserved", receipt.getBoolean("exited"))
            assertFalse(receipt.toString(), receipt.isNull("error"))
            return receipt.get("error").toString()
        }
        fun assertStopped(state: JSONObject, cleanupFailed: Boolean = false) {
            assertFalse(state.toString(), state.getBoolean("prepared"))
            assertFalse(state.toString(), state.getBoolean("attached"))
            assertEquals(state.toString(), cleanupFailed, state.getBoolean("cleanupFailed"))
        }
    }
}
