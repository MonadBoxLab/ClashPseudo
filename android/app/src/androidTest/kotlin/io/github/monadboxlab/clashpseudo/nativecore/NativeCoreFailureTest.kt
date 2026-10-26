package io.github.monadboxlab.clashpseudo.nativecore

import io.github.monadboxlab.clashpseudo.app.AppTrust
import io.github.monadboxlab.clashpseudo.vpn.NativeSession

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
import org.junit.Before
import org.junit.Test

class NativeCoreFailureTest {
    private val homes = mutableListOf<File>()
    private var ownsSession = false

    @Before
    fun requireIdleCore() {
        // A failed cleanup marks this process unusable for subsequent cases.
        assertFalse("Previous native cleanup was not confirmed", cleanupFailed.get())
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        CoreHost.installAndroid(context)
        val material = io.github.monadboxlab.clashpseudo.app.AppTrust.pem(context).toByteArray(Charsets.UTF_8)
        val error = NativeCore.initializeTrust(material)
        // Report the native error code only.
        assertEquals("AppTrust.pem -> NativeCore.initializeTrust raw error", "", error)
        assertStopped()
        ownsSession = true
    }

    @Test
    fun androidTrustPemInitializesNativeWithoutPreparingCore() {
        // The shared setup exercises the Java PEM, JNI and Go trust path.
        assertStopped()
    }

    @After
    fun cleanUp() {
        if (ownsSession) stop()
        homes.forEach { assertTrue("Cannot remove test directory $it", it.deleteRecursively()) }
    }

    @Test
    fun invalidParametersKeepDescriptorInKotlinAndRecover() {
        repeat(3) { round ->
            prepare(DIRECT, Protector(), vpn = true)
            val revision = JSONObject(NativeCore.vpnSpec()).getLong("revision")
            ParcelFileDescriptor.open(File("/dev/null"), ParcelFileDescriptor.MODE_READ_WRITE).use { descriptor ->
                val fd = descriptor.fd
                val error = NativeCore.attach(descriptor, revision + 1)
                assertTrue(error, error.contains("specification revision"))
                assertEquals(fd, descriptor.fd)
                Os.fstat(descriptor.fileDescriptor)
            }
            assertFalse(snapshot().getBoolean("attached"))
            stop()
            logResources("pre-detach-validation", round)
        }
    }

    @Test
    fun stackConstructionFailureConsumesDescriptorAndRecovers() {
        repeat(3) { round ->
            // Trigger deterministic failure in the default mips constructor.
            checkAttachFailure()
            logResources("stack", round)
        }
    }

    @Test
    fun kernelForwarderInterfaceQueryFailureConsumesDescriptorAndRecovers() {
        for (stack in listOf("system", "mixed")) repeat(3) { round ->
            val home = prepare(DIRECT + "tun: {stack: $stack}\n", Protector(), vpn = true)
            val revision = JSONObject(NativeCore.vpnSpec()).getLong("revision")
            val marker = File(home, "interface-query-marker").apply { writeBytes(byteArrayOf()) }
            val descriptor = ParcelFileDescriptor.open(marker, ParcelFileDescriptor.MODE_READ_WRITE)
            val fd = descriptor.fd
            val original = Os.fstat(descriptor.fileDescriptor)
            val error = descriptor.use { NativeCore.attach(it, revision) }
            assertTrue(error, error.contains("external TUN interface query"))
            assertConsumed(fd, original, error)
            assertFalse(snapshot().getBoolean("attached"))
            stop()
            prepare(DIRECT, Protector())
            stop()
            logResources("$stack-interface-query", round)
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
    fun connectionJniRejectsUnavailableCoreAndSummaryHasNoFullSnapshot() {
        val query = """{"limit":1000,"previousActiveIds":[]}""".toByteArray(Charsets.UTF_8)
        assertTrue(JSONObject(NativeCore.connections(query)).has("error"))
        assertTrue(JSONObject(NativeCore.connections(ByteArray(65537))).has("error"))
        assertEquals("failed", JSONObject(NativeCore.closeConnection("invalid".toByteArray()))
            .getString("status"))
        prepare(DIRECT, Protector())
        assertTrue(JSONObject(NativeCore.connections(query)).has("error"))
        val summary = snapshot()
        assertFalse(summary.has("traffic"))
        assertFalse(summary.has("connections"))
        assertTrue(summary.has("uploadTotal"))
        assertTrue(summary.has("downloadTotal"))
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

    @Test
    fun descriptorConsumptionChecksOriginalResourceAfterNumberReuse() {
        val cache = InstrumentationRegistry.getInstrumentation().targetContext.cacheDir
        val home = File(cache, "native-fd-probe-${UUID.randomUUID()}")
        assertTrue(home.mkdir())
        homes.add(home)
        val originalFile = File(home, "original").apply { writeBytes(byteArrayOf()) }
        val replacementFile = File(home, "replacement").apply { writeBytes(byteArrayOf()) }
        val descriptor = ParcelFileDescriptor.open(originalFile, ParcelFileDescriptor.MODE_READ_WRITE)
        val fd = descriptor.fd
        val original = Os.fstat(descriptor.fileDescriptor)
        try {
            val failure = try {
                assertConsumed(fd, original, "probe-only")
                null
            } catch (error: AssertionError) { error }
            assertNotNull("The probe accepted the still-open original resource", failure)
            assertTrue(failure!!.message.orEmpty().contains("still owns the original resource"))
        } finally { descriptor.close() }
        ParcelFileDescriptor.open(replacementFile, ParcelFileDescriptor.MODE_READ_WRITE).use {
            assertEquals("The fixture must actually reuse the descriptor number", fd, it.fd)
            assertNotEquals(original.st_ino, Os.fstat(it.fileDescriptor).st_ino)
            // The old EBADF-only criterion rejects this valid, independently owned reuse.
            ParcelFileDescriptor.fromFd(fd).use { duplicate -> Os.fstat(duplicate.fileDescriptor) }
            assertConsumed(fd, original, "probe-only")
        }
        assertConsumed(fd, original, "probe-only")
    }

    private fun checkAttachFailure() {
        val home = prepare(DIRECT + "tun: {congestion-controller: invalid-native-test-controller}\n", Protector(), vpn = true)
        val revision = JSONObject(NativeCore.vpnSpec()).getLong("revision")
        val marker = File(home, "descriptor-marker").apply { writeBytes(byteArrayOf()) }
        val descriptor = ParcelFileDescriptor.open(marker, ParcelFileDescriptor.MODE_READ_WRITE)
        val fd = descriptor.fd
        val original = Os.fstat(descriptor.fileDescriptor)
        val error = descriptor.use { NativeCore.attach(it, revision) }
        assertConsumed(fd, original, error)
        assertTrue(error, error.contains("invalid TCP congestion control"))
        assertFalse(snapshot().getBoolean("attached"))
        stop()
        prepare(DIRECT, Protector())
        stop()
    }

    private fun assertConsumed(fd: Int, original: android.system.StructStat, attachmentError: String) {
        val current = try {
            // fromFd duplicates the descriptor; inspect and close only that duplicate.
            ParcelFileDescriptor.fromFd(fd).use { Os.fstat(it.fileDescriptor) }
        } catch (error: IOException) {
            val errno = generateSequence<Throwable>(error) { it.cause }
                .filterIsInstance<ErrnoException>().firstOrNull()
            assertNotNull("Expected EBADF, got $error", errno)
            assertEquals(OsConstants.EBADF, errno!!.errno)
            return
        }
        assertFalse("Transferred descriptor $fd still owns the original resource; " +
            "original=${original.st_dev}/${original.st_ino}/${original.st_mode}, " +
            "current=${current.st_dev}/${current.st_ino}/${current.st_mode}, " +
            "attachment=$attachmentError",
            current.st_dev == original.st_dev && current.st_ino == original.st_ino)
    }

    private fun checkProtectFailure(throws: Boolean) {
        repeat(3) { round ->
            ProviderServer().use { server ->
                val rejected = Protector(accept = false, throws = throws)
                try {
                    // Preparation may succeed with an unavailable provider.
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
                    assertTrue("Explicit managed remote cache path was discarded", File(home, "provider.yaml").isFile)
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

    private fun prepare(body: String, protector: Protector, vpn: Boolean = false): File {
        val cache = InstrumentationRegistry.getInstrumentation().targetContext.cacheDir
        val home = File(cache, "native-failure-${UUID.randomUUID()}")
        assertTrue(home.mkdir())
        homes.add(home)
        val options = JSONObject().put("purpose", if (vpn) "VPN" else "PREVIEW")
            .put("generation", 1).put("composition", "native-failure-test").toString().toByteArray(Charsets.UTF_8)
        assertEquals("", NativeCore.prepare(home.path, body.toByteArray(Charsets.UTF_8), "rule", protector,
            options = options))
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

    class Protector(private val accept: Boolean = true, private val throws: Boolean = false) : NativeCore.PreparationCallbacks {
        val calls = AtomicInteger()
        private val invalidSocket = AtomicReference<Throwable?>()

        @Keep // JNI looks up this method by name, not through Kotlin call sites.
        override fun protectSocket(fd: Int): Boolean {
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

        @Keep override fun protectSocketOnNetwork(fd: Int, handle: String): Boolean = protectSocket(fd)
        override fun preparationOptions(): ByteArray = "{\"purpose\":\"PREVIEW\"}".toByteArray()
        @Keep override fun seedGeo(request: String): String = error("Unexpected Geo request in a test with explicit geox-url keys")
        @Keep override fun specificationChanged(generation: Long, composition: String, revision: Long, needed: Boolean) = Unit

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
        private const val DIRECT = "mode: rule\nfind-process-mode: off\nlog-level: info\ngeox-url: {geoip: '', geosite: '', mmdb: '', asn: ''}\nrules:\n  - MATCH,DIRECT\n"
        private val cleanupFailed = AtomicBoolean()
    }
}
