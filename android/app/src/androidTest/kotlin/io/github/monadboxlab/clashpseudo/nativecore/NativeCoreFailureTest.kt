package io.github.monadboxlab.clashpseudo.nativecore

import android.os.ParcelFileDescriptor
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.util.Log
import androidx.annotation.Keep
import androidx.test.platform.app.InstrumentationRegistry
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeFalse
import org.junit.Before
import org.junit.Test

class NativeCoreFailureTest {
    private val homes = mutableListOf<File>()
    private var ownsSession = false

    @Before
    fun requireIdleCore() {
        // A failed cleanup poisons this process; later tests must not reuse it.
        assumeFalse("Previous native cleanup was not confirmed", cleanupFailed.get())
        assertStopped()
        ownsSession = true
    }

    @After
    fun cleanUp() {
        if (ownsSession) stop()
        homes.forEach { assertTrue("Cannot remove test directory $it", it.deleteRecursively()) }
    }

    @Test
    fun invalidParametersConsumeDescriptorAndRecover() {
        repeat(3) { round ->
            checkAttachFailure(33, "invalid IPv4 TUN parameters")
            logResources("parameters", round)
        }
    }

    @Test
    fun stackConstructionFailureConsumesDescriptorAndRecovers() {
        repeat(3) { round ->
            // /32 passes our validation, but system stack needs a second address.
            checkAttachFailure(32, "need one more IPv4 address")
            logResources("stack", round)
        }
    }

    @Test
    fun refusedProtectPreventsConnectionAndRecovers() {
        checkProtectFailure(throws = false)
    }

    @Test
    fun throwingProtectIsContainedAndRecovers() {
        checkProtectFailure(throws = true)
    }

    @Test
    fun modeRoundTripRejectsInvalidInputAndClearsOnStop() {
        prepare(DIRECT, Protector())
        assertEquals("rule", NativeCore.mode())
        for (mode in listOf("global", "direct", "rule")) {
            assertEquals("", NativeCore.setMode(mode))
            assertEquals(mode, NativeCore.mode())
        }
        assertTrue(NativeCore.setMode("follow").isNotEmpty())
        assertEquals("rule", NativeCore.mode())
        stop()
        assertEquals("", NativeCore.mode())
        assertTrue(NativeCore.setMode("direct").isNotEmpty())
    }

    @Test
    fun previewUsesRealJniUtf8AndRestoresWithoutTun() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val session = io.github.monadboxlab.clashpseudo.vpn.NativeSession()
        lateinit var host: CoreHost
        instrumentation.runOnMainSync {
            host = CoreHost(session, {})
            host.setVisible(true)
        }
        val home = File(instrumentation.targetContext.cacheDir, "native-strategy-${UUID.randomUUID()}")
        assertTrue(home.mkdir())
        homes.add(home)
        val body = DIRECT + """
            proxies:
              - {name: 节点🌐, type: direct}
            proxy-groups:
              - {name: 出口🌐, type: select, proxies: [DIRECT, 节点🌐, REJECT]}
        """.trimIndent() + "\n"
        val choice = JSONObject().put("type", "select").put("member", "节点🌐")
        val choices = JSONObject().put("出口🌐", choice).toString().toByteArray(Charsets.UTF_8)
        fun selected(): String {
            val groups = JSONObject(NativeCore.strategies()).getJSONArray("groups")
            return (0 until groups.length()).map { groups.getJSONObject(it) }
                .single { it.getString("name") == "出口🌐" }.getString("now")
        }
        try {
            val loaded = host.preparePreview("first", "one", 1, home.path, { true }) {
                CoreInput("one", 1, "rule", body.toByteArray(Charsets.UTF_8), choices)
            }
            assertTrue(host.current(loaded.generation))
            assertEquals("节点🌐", selected())
            assertFalse(snapshot().getBoolean("attached"))
            assertEquals(io.github.monadboxlab.clashpseudo.vpn.NativeSession.Phase.STOPPED,
                session.snapshot().phase)
            val request = JSONObject().put("name", "出口🌐")
                .put("choice", JSONObject().put("type", "select").put("member", "REJECT"))
            assertEquals("", NativeCore.setStrategy(request.toString().toByteArray(Charsets.UTF_8)))
            assertEquals("REJECT", selected())
            request.put("choice", choice)
            assertEquals("", NativeCore.setStrategy(request.toString().toByteArray(Charsets.UTF_8)))
            assertEquals("节点🌐", selected())
            assertNull(host.releasePreview())
            assertStopped()
        } finally {
            assertNull(host.releasePreview())
        }
    }

    private fun checkAttachFailure(prefix: Int, expected: String) {
        prepare(DIRECT, Protector())
        val fd = ParcelFileDescriptor.open(File("/dev/null"), ParcelFileDescriptor.MODE_READ_WRITE)
            .use { it.detachFd() }
        val error = NativeCore.attach(fd, 1400, "192.0.2.1", prefix)
        // Probe before snapshot/logging can allocate another descriptor with this number.
        assertConsumed(fd)
        assertTrue(error, error.contains(expected))
        assertFalse(snapshot().getBoolean("attached"))
        stop()
        prepare(DIRECT, Protector())
        stop()
    }

    private fun assertConsumed(fd: Int) {
        try {
            // fromFd duplicates: never adopt/close the transferred number, which may be reused.
            ParcelFileDescriptor.fromFd(fd).close()
        } catch (error: IOException) {
            val errno = generateSequence<Throwable>(error) { it.cause }
                .filterIsInstance<ErrnoException>().firstOrNull()
            assertNotNull("Expected EBADF, got $error", errno)
            assertEquals(OsConstants.EBADF, errno!!.errno)
            return
        }
        fail("Transferred descriptor $fd remains open")
    }

    private fun checkProtectFailure(throws: Boolean) {
        repeat(3) { round ->
            ProviderServer().use { server ->
                val rejected = Protector(accept = false, throws = throws)
                try {
                    // mihomo tolerates an unavailable provider; prepare need not fail.
                    prepare(providerConfig(server), rejected)
                    rejected.assertCalled()
                    val state = snapshot()
                    assertEquals(rejected.calls.get().toLong(), state.getLong("refused"))
                    assertEquals(0L, state.getLong("protected"))
                    assertEquals(0, server.accepted.get())
                } finally {
                    stop()
                }
            }
            ProviderServer().use { server ->
                val accepted = Protector()
                try {
                    val home = prepare(providerConfig(server), accepted)
                    assertTrue("Provider response not sent", server.served.await(3, TimeUnit.SECONDS))
                    server.assertHealthy()
                    accepted.assertCalled()
                    assertTrue(snapshot().getLong("protected") > 0)
                    assertEquals(0L, snapshot().getLong("refused"))
                    assertFalse("Remote cache path must be ignored", File(home, "provider.yaml").exists())
                    val expected = server.body.toByteArray(Charsets.UTF_8)
                    assertEquals(1, home.walkTopDown().filter { it.isFile }
                        .count { it.readBytes().contentEquals(expected) })
                } finally {
                    stop()
                }
            }
            logResources(if (throws) "throw" else "refuse", round)
        }
    }

    private fun prepare(body: String, protector: Protector): File {
        val cache = InstrumentationRegistry.getInstrumentation().targetContext.cacheDir
        val home = File(cache, "native-failure-${UUID.randomUUID()}")
        assertTrue(home.mkdir())
        homes.add(home)
        assertEquals("", NativeCore.prepare(home.path, body.toByteArray(Charsets.UTF_8), "rule", protector))
        assertTrue(snapshot().getBoolean("prepared"))
        return home
    }

    private fun stop() {
        try {
            NativeCore.cancel()
            assertEquals("", NativeCore.stop())
            assertStopped()
        } catch (failure: Throwable) {
            cleanupFailed.set(true)
            throw failure
        }
    }

    private fun assertStopped() {
        val state = snapshot()
        assertFalse(state.toString(), state.getBoolean("prepared"))
        assertFalse(state.toString(), state.getBoolean("attached"))
        assertFalse(state.toString(), state.getBoolean("cleanupFailed"))
    }

    private fun snapshot() = JSONObject(NativeCore.snapshot())

    private fun logResources(scene: String, round: Int) {
        val workers = Thread.getAllStackTraces().keys.count { it.name == "native-test-provider" && it.isAlive }
        assertEquals("Provider test thread survived cleanup", 0, workers)
        Log.i("NativeCoreFailureTest", "$scene round=$round pid=${android.os.Process.myPid()} " +
            "fds=${File("/proc/self/fd").list()!!.size} providerThreads=$workers")
    }

    private fun providerConfig(server: ProviderServer) = DIRECT + """
        proxy-providers:
          fixture:
            type: http
            url: http://127.0.0.1:${server.port}/${server.requestId}
            path: ./provider.yaml
            interval: 0
            health-check: {enable: false}
    """.trimIndent() + "\n"

    class Protector(private val accept: Boolean = true, private val throws: Boolean = false) {
        val calls = AtomicInteger()
        private val invalidSocket = AtomicReference<Throwable?>()

        @Keep // JNI looks up this method by name, not through Kotlin call sites.
        fun protectSocket(fd: Int): Boolean {
            calls.incrementAndGet()
            try {
                ParcelFileDescriptor.fromFd(fd).use {
                    check(OsConstants.S_ISSOCK(Os.fstat(it.fileDescriptor).st_mode))
                }
            } catch (failure: Throwable) {
                // JNI clears callback exceptions, so preserve validation failures separately.
                invalidSocket.compareAndSet(null, failure)
                return false
            }
            if (throws) throw IllegalStateException("Injected protect callback failure")
            return accept
        }

        fun assertCalled() {
            assertTrue("JNI never called protectSocket", calls.get() > 0)
            invalidSocket.get()?.let { throw AssertionError("Callback did not receive a socket", it) }
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
        val port: Int = listener.localPort
        private val worker = Thread({
            try {
                listener.soTimeout = 15000
                listener.accept().use { socket ->
                    client.set(socket)
                    socket.soTimeout = 3000
                    accepted.incrementAndGet()
                    val input = socket.getInputStream().bufferedReader(Charsets.US_ASCII)
                    check(input.readLine() == "GET /$requestId HTTP/1.1")
                    while (true) {
                        val line = input.readLine() ?: error("Incomplete HTTP headers")
                        if (line.isEmpty()) break
                    }
                    val bytes = body.toByteArray(Charsets.UTF_8)
                    val output = socket.getOutputStream()
                    output.write(("HTTP/1.1 200 OK\r\nContent-Length: ${bytes.size}\r\n" +
                        "Connection: close\r\n\r\n").toByteArray(Charsets.US_ASCII))
                    output.write(bytes)
                    output.flush()
                    served.countDown()
                }
            } catch (error: Throwable) {
                if (!closing.get()) failure.set(error)
            }
        }, "native-test-provider").apply { start() }

        fun assertHealthy() {
            failure.get()?.let { throw AssertionError("Provider server failed", it) }
        }

        override fun close() {
            closing.set(true)
            try {
                listener.close()
                client.get()?.close()
            } finally {
                worker.join(5000)
            }
            assertFalse("Provider thread did not exit", worker.isAlive)
            assertHealthy()
        }
    }

    companion object {
        private const val DIRECT = "mode: rule\nfind-process-mode: off\nlog-level: info\nrules:\n  - MATCH,DIRECT\n"
        private val cleanupFailed = AtomicBoolean()
    }
}
